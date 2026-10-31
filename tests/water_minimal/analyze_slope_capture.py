"""Offline inspection of the S capture; no Godot rendering or scene edits."""
import json, math
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).parent
STEM = 'water_replay_20261031_152927_414660'
state = json.loads((ROOT/'captures/water_repro_20261031_143746_684620.json').read_text())
im = np.asarray(Image.open(ROOT/f'captures/{STEM}_S_raw_micro_slope.png').convert('RGB'))
roi = im[700:1080]
def linear(v):
    v = np.asarray(v, dtype=float)/255
    return np.where(v<=.04045,v/12.92,((v+.055)/1.055)**2.4)
slopes = (linear(roi[:,:,:2])-.5)*.5
f = np.float32
def fract(p): return p-np.floor(p)
def hash_value(p):
    v=fract(np.array([p[0],p[1],p[0]],dtype=np.float32)*np.array([.1031,.1030,.0973],dtype=np.float32))
    v=v+np.dot(v,v[[1,2,0]]+f(33.33))
    return fract((v[0]+v[1])*v[2])
def gradient(p):
    p=np.asarray(p,dtype=np.float32); c=np.floor(p); t=fract(p)
    u=t*t*t*(t*(t*f(6)-f(15))+f(10)); du=f(30)*t*t*(t-f(1))*(t-f(1))
    a,b,c0,d=[hash_value(c+offset) for offset in [np.array([0,0]),np.array([1,0]),np.array([0,1]),np.array([1,1])]]
    r0=a+(b-a)*u[0]; r1=c0+(d-c0)*u[0]
    return np.array([((b-a)*du[0])*(1-u[1])+(d-c0)*du[0]*u[1],(r1-r0)*du[1]])
def fbm(p):
    return gradient(p)*f(.62)+gradient(p*f(2.03)+np.array([17.1,9.2],dtype=np.float32))*f(.27*2.03)+gradient(p*f(4.11)+np.array([37.7,23.4],dtype=np.float32))*f(.11*4.11)
def rotate(p,a):
    c,s=f(math.cos(a)),f(math.sin(a)); return np.array([c*p[0]-s*p[1],s*p[0]+c*p[1]],dtype=np.float32)
def micro(p):
    w=state['water_shader_parameters']; direction=np.array(w['ripple_direction'],dtype=np.float32)+np.array([.0001,0],dtype=np.float32); direction/=np.linalg.norm(direction)
    da=direction*f(w['WaveTime']*w['ripple_speed']); db=np.array([-direction[1],direction[0]])*f(w['WaveTime']*w['ripple_speed']*.73)
    p=np.array(p,dtype=np.float32)
    pa=rotate(p+da,.39)*f(.17); pb=rotate(p-db,-.71)*f(.17*.79)+np.array([31.7,12.4],dtype=np.float32)
    return rotate(fbm(pa),-.39)*f(.17*.64)+rotate(fbm(pb),.71)*f(.17*.79*.36)
w=state['water_shader_parameters']; camera=np.array(state['camera']['world_position'])
pitch,yaw,_=np.radians(state['camera']['world_rotation_degrees'])
right=np.array([math.cos(yaw),0,-math.sin(yaw)])
up=np.array([math.sin(yaw)*math.sin(pitch),math.cos(pitch),math.cos(yaw)*math.sin(pitch)])
forward=np.array([-math.sin(yaw)*math.cos(pitch),math.sin(pitch),-math.cos(yaw)*math.cos(pitch)])
def surface(u,v):
    p=np.array([u,0.,v]); tx=np.array([1.,0.,0.]); tz=np.array([0.,0.,1.]); n=w['WaveCount']
    for i in range(n):
        a=w['WaveAmplitudes'][i]; s=w['WaveSteepnesses'][i]; d=math.radians(w['WaveDirectionsDegrees'][i]); dx,dz=math.sin(d),math.cos(d)
        k=math.tau*w['WaveFrequencies'][i]; th=k*(dx*u+dz*v)+w['WaveSpeeds'][i]*(w['WaveTime']+math.radians(w['WavePhases'][i])); sn,cs=math.sin(th),math.cos(th)
        p+=np.array([s*a*dx*cs,s*sn,s*a*dz*cs])/n
        derivative=np.array([-s*a*dx*sn,s*cs,-s*a*dz*sn]); tx+=derivative*k*dx/n; tz+=derivative*k*dz/n
    return p,tx,tz
def intersection(x,y):
    tv=math.tan(math.radians(58)/2); ray=forward+right*((2*(x+.5)/1920-1)*tv*1920/1080)+up*((1-2*(y+.5)/1080)*tv); ray/=np.linalg.norm(ray)
    distance=-camera[1]/ray[1]; q=np.array([camera[0]+distance*ray[0],camera[2]+distance*ray[2],distance])
    for _ in range(8):
        p,tx,tz=surface(q[0],q[1]); q-=np.linalg.solve(np.column_stack([tx,tz,-ray]),p-camera-q[2]*ray)
    continuous=surface(q[0],q[1])[0]
    hits=[]
    for u in range(math.floor(q[0])-2,math.floor(q[0])+3):
        for v in range(math.floor(q[1])-2,math.floor(q[1])+3):
            vertices=[surface(u+du,v+dv)[0] for du,dv in [(0,0),(1,0),(1,1),(0,1)]]
            for indices in [(0,1,2),(0,2,3)]:
                a,b,c=[vertices[i] for i in indices]
                b0,b1,distance=np.linalg.solve(np.column_stack([b-a,c-a,-ray]),camera-a)
                if b0>=0 and b1>=0 and b0+b1<=1 and distance>0:
                    hits.append((distance,camera+distance*ray,[u,v,list(indices)]))
    hit=min(hits,key=lambda item:item[0]) if hits else None
    return continuous,q[:2],hit
hash_variants=[]
hash_constants=np.array([.1031,.1030,.0973],dtype=np.float32)
for hx in [5271,5272]:
    for offset in [0,1]:
        base=np.array([hx,9770-offset,hx],dtype=np.float32)
        off=np.array([0,offset,0],dtype=np.float32)
        for name,initial in [('materialized',(base+off)*hash_constants),('distributed',base*hash_constants+off*hash_constants)]:
            v=fract(initial); v=v+np.dot(v,v[[1,2,0]]+f(33.33)); product=(v[0]+v[1])*v[2]
            hash_variants.append(dict(corner=[hx,9770],offset=offset,evaluation=name,prefract_product=float(product),hash=float(fract(product))))
points=[]
drift_direction=np.array(w['ripple_direction'],dtype=np.float32)+np.array([.0001,0],dtype=np.float32)
drift_direction/=np.linalg.norm(drift_direction)
drift_a=drift_direction*f(w['WaveTime']*w['ripple_speed'])
for x in range(1698,1704):
    p,source,hit=intersection(x,751)
    high_a=(rotate(hit[1][[0,2]].astype(np.float32)+drift_a,.39)*f(.17))*f(4.11)+np.array([37.7,23.4],dtype=np.float32)
    points.append(dict(pixel=[x,751],approx_continuous_surface_world=p.tolist(),source_xz=source.tolist(),cpu_slope=micro(p[[0,2]]).tolist(),triangulated_world=hit[1].tolist() if hit else None,triangle=hit[2] if hit else None,triangulated_cpu_slope=micro(hit[1][[0,2]]).tolist() if hit else None,high_a_noise_coordinate=high_a.tolist(),gpu_slope_from_png=((linear(im[751,x,:2])-.5)*.5).tolist()))
def corner_hash(x,evaluation):
    return next(v['hash'] for v in hash_variants if v['corner'][0]==x and v['offset']==1 and v['evaluation']==evaluation)
fraction=(points[2]['high_a_noise_coordinate'][0]+points[3]['high_a_noise_coordinate'][0])/2 % 1
du=30*fraction*fraction*(fraction-1)**2
delta_corner_difference=(corner_hash(5272,'distributed')-corner_hash(5271,'distributed'))-(corner_hash(5272,'materialized')-corner_hash(5271,'materialized'))
predicted=rotate(np.array([delta_corner_difference*du*(.11*4.11)*.17*.64,0],dtype=np.float32),-.39)
observed=np.array(points[3]['gpu_slope_from_png'])-np.array(points[2]['gpu_slope_from_png'])
result=dict(roi=[0,700,1920,1080],pixels=int(roi.shape[0]*roi.shape[1]),blue_clipping_pixels=int(np.count_nonzero(roi[:,:,2]>128)),estimated_gpu_slope_min=slopes.min((0,1)).tolist(),estimated_gpu_slope_max=slopes.max((0,1)).tolist(),notes='PNG values have 8-bit/display quantization. Offline ray intersections include continuous surface and central 1m mesh reconstruction; no GPU coordinate buffer was read. Float32 hash expression variants demonstrate sensitivity, not actual GPU instruction selection.',edge_samples=points,shared_corner_hash_variants=hash_variants,predicted_world_slope_jump=predicted.tolist(),observed_world_slope_jump=observed.tolist(),jump_difference_norm=float(np.linalg.norm(predicted-observed)))
(ROOT/f'captures/{STEM}_slope_analysis.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__ == '__main__':
    print(json.dumps(result,indent=2))
